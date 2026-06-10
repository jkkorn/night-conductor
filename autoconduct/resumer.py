"""Resume a stalled session headlessly via the claude CLI."""

from __future__ import annotations

import subprocess
from dataclasses import dataclass

from .conductor_db import StalledSession
from .config import Config

RESUME_TIMEOUT_SECONDS = 60 * 60  # one long agentic run, but never forever


@dataclass(frozen=True)
class ResumeResult:
    session_id: str
    ok: bool
    detail: str


def resume_session(
    session: StalledSession, config: Config, dry_run: bool = False
) -> ResumeResult:
    """Run `claude --resume` in the session's workspace directory.

    Headless print mode (-p) so the run terminates on its own. Work lands
    in the workspace files/git; Conductor's chat UI won't show the turns.
    """
    cmd = [
        "claude",
        "--resume",
        session.claude_session_id,
        "-p",
        config.resume_prompt,
        "--permission-mode",
        config.permission_mode,
    ]
    if dry_run:
        return ResumeResult(session.session_id, True, f"DRY RUN: {' '.join(cmd)}")
    try:
        proc = subprocess.run(
            cmd,
            cwd=session.workspace_path,
            capture_output=True,
            text=True,
            timeout=RESUME_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return ResumeResult(session.session_id, False, "timed out after 1h")
    except FileNotFoundError:
        return ResumeResult(session.session_id, False, "claude CLI not found on PATH")
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip()[-300:]
        return ResumeResult(session.session_id, False, f"exit {proc.returncode}: {tail}")
    return ResumeResult(session.session_id, True, (proc.stdout or "").strip()[-300:])
