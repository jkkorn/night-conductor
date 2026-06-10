"""Read-only scanner for Conductor's session database.

Finds sessions whose most recent message is a 429 usage-limit error —
i.e. the session stalled at the limit and nothing has happened since.
The database is opened with mode=ro; this module never writes.
"""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

DB_PATH = (
    Path.home()
    / "Library"
    / "Application Support"
    / "com.conductor.app"
    / "conductor.db"
)

_LAST_MESSAGE_QUERY = """
WITH last_msgs AS (
    SELECT session_id, content, created_at,
           ROW_NUMBER() OVER (
               PARTITION BY session_id ORDER BY created_at DESC
           ) AS rn
    FROM session_messages
)
SELECT s.id, s.claude_session_id, s.title, w.workspace_path,
       lm.content, lm.created_at
FROM last_msgs lm
JOIN sessions s ON s.id = lm.session_id
JOIN workspaces w ON w.id = s.workspace_id
WHERE lm.rn = 1
  AND w.state = 'active'
  AND lm.content LIKE '%api_error_status%'
"""


@dataclass(frozen=True)
class StalledSession:
    session_id: str
    claude_session_id: str
    title: str
    workspace_path: str
    error_text: str  # e.g. "You've hit your session limit · resets 1:30pm"
    stalled_at: datetime


def _is_limit_error(payload: dict) -> bool:
    return (
        payload.get("type") == "result"
        and payload.get("is_error") is True
        and payload.get("api_error_status") == 429
    )


def _parse_row(row: tuple) -> StalledSession | None:
    session_id, claude_session_id, title, workspace_path, content, created = row
    try:
        payload = json.loads(content)
    except json.JSONDecodeError:
        return None
    if not _is_limit_error(payload):
        return None
    if not claude_session_id or not workspace_path:
        return None
    if not Path(workspace_path).is_dir():
        return None  # workspace was removed; nothing to resume into
    stalled_at = datetime.fromisoformat(created.replace("Z", "+00:00"))
    if stalled_at.tzinfo is None:
        stalled_at = stalled_at.replace(tzinfo=timezone.utc)
    return StalledSession(
        session_id=session_id,
        claude_session_id=claude_session_id,
        title=title or "Untitled",
        workspace_path=workspace_path,
        error_text=str(payload.get("result", "")),
        stalled_at=stalled_at,
    )


def find_stalled_sessions(db_path: Path = DB_PATH) -> tuple[StalledSession, ...]:
    """Return all sessions currently stalled on a usage-limit error."""
    if not db_path.exists():
        raise FileNotFoundError(f"Conductor DB not found at {db_path}")
    uri = f"file:{db_path}?mode=ro"
    with sqlite3.connect(uri, uri=True, timeout=10) as conn:
        rows = conn.execute(_LAST_MESSAGE_QUERY).fetchall()
    parsed = (_parse_row(row) for row in rows)
    return tuple(s for s in parsed if s is not None)
