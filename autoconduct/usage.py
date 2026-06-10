"""Query Claude subscription usage via the OAuth endpoint.

Uses the OAuth access token Claude Code already stores in the macOS
Keychain (service: "Claude Code-credentials"). Read-only; no secrets are
ever written to disk or logs.
"""

from __future__ import annotations

import json
import subprocess
import urllib.request
from dataclasses import dataclass
from datetime import datetime

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"


@dataclass(frozen=True)
class Window:
    """One rate-limit window: percent used and when it resets."""

    utilization: float  # 0..100
    resets_at: datetime | None


@dataclass(frozen=True)
class UsageSnapshot:
    five_hour: Window
    seven_day: Window
    fetched_at: datetime


class UsageError(RuntimeError):
    """Raised when usage cannot be determined. Callers must fail closed."""


def _read_oauth_token() -> str:
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        ).stdout.strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise UsageError(f"Cannot read Claude credentials from Keychain: {exc}") from exc
    try:
        return json.loads(out)["claudeAiOauth"]["accessToken"]
    except (json.JSONDecodeError, KeyError) as exc:
        raise UsageError("Unexpected Keychain credential format") from exc


def _parse_window(raw: dict | None) -> Window:
    if not raw:
        return Window(utilization=0.0, resets_at=None)
    resets = raw.get("resets_at")
    return Window(
        utilization=float(raw.get("utilization") or 0.0),
        resets_at=datetime.fromisoformat(resets) if resets else None,
    )


def parse_usage(payload: dict, fetched_at: datetime) -> UsageSnapshot:
    """Parse the /api/oauth/usage payload into an immutable snapshot."""
    return UsageSnapshot(
        five_hour=_parse_window(payload.get("five_hour")),
        seven_day=_parse_window(payload.get("seven_day")),
        fetched_at=fetched_at,
    )


def fetch_usage(now: datetime) -> UsageSnapshot:
    token = _read_oauth_token()
    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001 — network errors must fail closed
        raise UsageError(f"Usage endpoint unreachable: {exc}") from exc
    return parse_usage(payload, fetched_at=now)
