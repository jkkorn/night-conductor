"""Budget policy: decide whether it's safe to resume sessions right now.

This is the brain of autoconduct. Everything else is plumbing.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from .config import Config
from .usage import UsageSnapshot


@dataclass(frozen=True)
class Decision:
    resume: bool
    reason: str  # always explain — shown in `autoconduct status` and logs


def in_active_hours(now: datetime, active_hours: tuple[int, int]) -> bool:
    """True if `now` falls in the [start, end) window, handling midnight wrap.

    active_hours=(23, 7) means 23:00 tonight through 06:59 tomorrow.
    """
    start, end = active_hours
    if start == end:
        return True  # degenerate config: always active
    if start < end:
        return start <= now.hour < end
    return now.hour >= start or now.hour < end


def days_until_weekly_reset(usage: UsageSnapshot, now: datetime) -> float:
    """Days (fractional) until the 7-day window resets. 0.0 if unknown/past."""
    resets_at = usage.seven_day.resets_at
    if resets_at is None:
        return 0.0
    delta = (resets_at - now).total_seconds() / 86400.0
    return max(0.0, delta)


def should_resume(usage: UsageSnapshot, config: Config, now: datetime) -> Decision:
    """Decide whether resuming sessions right now is budget-safe.

    Hard gates (already implemented below): active hours and absolute
    ceilings. The interesting part — the weekly "wiggle room" heuristic —
    is TODO and intentionally left open:

    Inputs available:
      - usage.five_hour.utilization   (0..100, resets every 5h)
      - usage.seven_day.utilization   (0..100)
      - days_until_weekly_reset(usage, now)  (e.g. 1.8 days)
      - config.weekly_ceiling         (absolute stop line, default 90)

    The question: with X% of the week consumed and D days left, is there
    "plenty of wiggle room"? E.g. 70% used with 0.5 days left is fine;
    70% used with 5 days left means the week is being burned too fast.
    """
    if not in_active_hours(now, config.active_hours):
        return Decision(False, f"outside active hours {config.active_hours}")

    if usage.five_hour.utilization >= config.five_hour_ceiling:
        return Decision(
            False,
            f"5h window at {usage.five_hour.utilization:.0f}% "
            f"(ceiling {config.five_hour_ceiling:.0f}%)",
        )

    if usage.seven_day.utilization >= config.weekly_ceiling:
        return Decision(
            False,
            f"weekly window at {usage.seven_day.utilization:.0f}% "
            f"(ceiling {config.weekly_ceiling:.0f}%)",
        )

    # TODO(user): implement the weekly pacing heuristic.
    #
    # Decide whether the *rate* of weekly consumption leaves wiggle room,
    # not just whether we're under the absolute ceiling. Return:
    #   Decision(False, "<why>")  -> too risky, skip this tick
    #   Decision(True, "<why>")   -> safe, go resume sessions
    #
    # Sketch of one possible approach (linear pacing):
    #   week_used = usage.seven_day.utilization          # e.g. 29.0
    #   days_left = days_until_weekly_reset(usage, now)  # e.g. 1.6
    #   ...compare week_used against how far through the week we are,
    #   possibly with a safety margin so mornings aren't starved.

    return Decision(True, "under ceilings (pacing heuristic not yet implemented)")
