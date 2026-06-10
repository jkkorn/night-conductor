"""One daemon tick: scan → budget-gate → resume sequentially → re-check."""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from . import conductor_db, policy, state, usage
from .config import Config
from .resumer import resume_session

log = logging.getLogger("autoconduct")


def _eligible(sessions, night: state.NightState, config: Config):
    return tuple(
        s
        for s in sessions
        if night.count_for(s.session_id) < config.max_resumes_per_session
    )


def run_tick(config: Config, dry_run: bool = False) -> state.NightState:
    """Execute one scheduling tick. Returns the resulting night state."""
    now = datetime.now(timezone.utc)
    key = state.night_key(now.astimezone(), config.active_hours[0])
    night = state.load_state(key)

    try:
        snapshot = usage.fetch_usage(now)
    except usage.UsageError as exc:
        log.warning("Cannot determine usage, failing closed: %s", exc)
        return night  # no usage data -> never resume

    decision = policy.should_resume(snapshot, config, now.astimezone())
    log.info(
        "5h=%.0f%% weekly=%.0f%% -> resume=%s (%s)",
        snapshot.five_hour.utilization,
        snapshot.seven_day.utilization,
        decision.resume,
        decision.reason,
    )
    if not decision.resume:
        return night

    stalled = conductor_db.find_stalled_sessions()
    candidates = _eligible(stalled, night, config)
    log.info("%d stalled session(s), %d eligible", len(stalled), len(candidates))

    for session in candidates:
        if night.total_resumes() >= config.max_sessions_per_night:
            log.info("Nightly cap reached (%d)", config.max_sessions_per_night)
            break

        log.info("Resuming %s (%s)", session.title, session.session_id[:8])
        result = resume_session(session, config, dry_run=dry_run)
        log.info("Result %s: ok=%s %s", session.session_id[:8], result.ok, result.detail)

        night = night.with_resume(session.session_id)
        if not dry_run:
            state.save_state(night)

        # Re-check the budget after every resume — a long agentic run can
        # consume a big chunk of the 5h window on its own.
        now = datetime.now(timezone.utc)
        try:
            snapshot = usage.fetch_usage(now)
        except usage.UsageError as exc:
            log.warning("Usage re-check failed, stopping: %s", exc)
            break
        decision = policy.should_resume(snapshot, config, now.astimezone())
        if not decision.resume:
            log.info("Stopping after re-check: %s", decision.reason)
            break

    return night
