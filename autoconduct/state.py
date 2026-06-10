"""Persistent state: how many times each session was resumed tonight.

Stored as JSON in ~/.local/state/autoconduct/. A "night" is keyed by the
date the active window started, so 23:00 and 02:00 share one budget.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

STATE_PATH = Path.home() / ".local" / "state" / "autoconduct" / "state.json"


@dataclass(frozen=True)
class NightState:
    night_key: str  # e.g. "2026-06-10"
    resume_counts: dict[str, int] = field(default_factory=dict)

    def count_for(self, session_id: str) -> int:
        return self.resume_counts.get(session_id, 0)

    def total_resumes(self) -> int:
        return sum(self.resume_counts.values())

    def with_resume(self, session_id: str) -> "NightState":
        """Return a new state with one more resume recorded (immutable)."""
        counts = {**self.resume_counts}
        counts[session_id] = counts.get(session_id, 0) + 1
        return NightState(night_key=self.night_key, resume_counts=counts)


def night_key(now: datetime, active_start_hour: int) -> str:
    """Date string for the night this moment belongs to.

    Hours before the start hour (e.g. 02:00 with start 23) belong to the
    previous calendar date's night.
    """
    anchor = now if now.hour >= active_start_hour else now - timedelta(days=1)
    return anchor.date().isoformat()


def load_state(key: str, path: Path = STATE_PATH) -> NightState:
    if not path.exists():
        return NightState(night_key=key)
    try:
        raw = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return NightState(night_key=key)
    if raw.get("night_key") != key:
        return NightState(night_key=key)  # new night, fresh budget
    return NightState(night_key=key, resume_counts=dict(raw.get("resume_counts", {})))


def save_state(state: NightState, path: Path = STATE_PATH) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"night_key": state.night_key, "resume_counts": state.resume_counts}
    path.write_text(json.dumps(payload, indent=2) + "\n")
