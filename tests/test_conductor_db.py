import json
import sqlite3

import pytest

from autoconduct.conductor_db import find_stalled_sessions

LIMIT_ERROR = {
    "type": "result",
    "subtype": "success",
    "is_error": True,
    "api_error_status": 429,
    "result": "You've hit your session limit · resets 1:30pm (America/Sao_Paulo)",
}

OK_RESULT = {"type": "result", "subtype": "success", "is_error": False}


@pytest.fixture
def db(tmp_path):
    path = tmp_path / "conductor.db"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, claude_session_id TEXT,
            workspace_id TEXT, title TEXT
        );
        CREATE TABLE workspaces (
            id TEXT PRIMARY KEY, workspace_path TEXT, state TEXT
        );
        CREATE TABLE session_messages (
            id TEXT PRIMARY KEY, session_id TEXT,
            content TEXT, created_at TEXT
        );
        """
    )
    conn.commit()
    yield conn, path
    conn.close()


def _seed(conn, tmp_path, session_id, messages, ws_state="active", ws_exists=True):
    ws_path = tmp_path / f"ws-{session_id}"
    if ws_exists:
        ws_path.mkdir(exist_ok=True)
    conn.execute(
        "INSERT INTO workspaces VALUES (?, ?, ?)",
        (f"ws-{session_id}", str(ws_path), ws_state),
    )
    conn.execute(
        "INSERT INTO sessions VALUES (?, ?, ?, ?)",
        (session_id, f"claude-{session_id}", f"ws-{session_id}", f"Task {session_id}"),
    )
    for i, payload in enumerate(messages):
        conn.execute(
            "INSERT INTO session_messages VALUES (?, ?, ?, ?)",
            (
                f"{session_id}-m{i}",
                session_id,
                json.dumps(payload),
                f"2026-06-10T0{i}:00:00.000Z",
            ),
        )
    conn.commit()


class TestFindStalledSessions:
    def test_finds_session_ending_in_429(self, db, tmp_path):
        conn, path = db
        _seed(conn, tmp_path, "s1", [OK_RESULT, LIMIT_ERROR])
        stalled = find_stalled_sessions(path)
        assert len(stalled) == 1
        assert stalled[0].session_id == "s1"
        assert "resets 1:30pm" in stalled[0].error_text

    def test_ignores_session_that_recovered(self, db, tmp_path):
        conn, path = db
        _seed(conn, tmp_path, "s2", [LIMIT_ERROR, OK_RESULT])
        assert find_stalled_sessions(path) == ()

    def test_ignores_archived_workspace(self, db, tmp_path):
        conn, path = db
        _seed(conn, tmp_path, "s3", [LIMIT_ERROR], ws_state="archived")
        assert find_stalled_sessions(path) == ()

    def test_ignores_deleted_workspace_dir(self, db, tmp_path):
        conn, path = db
        _seed(conn, tmp_path, "s4", [LIMIT_ERROR], ws_exists=False)
        assert find_stalled_sessions(path) == ()

    def test_missing_db_raises(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            find_stalled_sessions(tmp_path / "missing.db")

    def test_result_is_immutable_tuple(self, db, tmp_path):
        conn, path = db
        _seed(conn, tmp_path, "s5", [LIMIT_ERROR])
        assert isinstance(find_stalled_sessions(path), tuple)
