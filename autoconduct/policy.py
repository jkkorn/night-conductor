"""Budget policy: decide whether it's safe to resume sessions right now.

This is the brain of autoconduct. Everything else is plumbing.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from .config import Config
from .usage import UsageSnapshot

# Extra weekly headroom (percentage points) the pacing gate always preserves
# beyond linear pace, so overnight runs never starve the next workdays.
PACING_MARGIN = 15.0

# Length of Claude's rolling session window. A session started now anchors a
# window that stays "hot" for this many hours.
FIVE_HOUR_WINDOW = 5.0


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


def hours_until_wake(now: datetime, wake_hour: int) -> float:
    """Hours (fractional) until the next occurrence of wake_hour:00."""
    now_frac = now.hour + now.minute / 60.0
    return (wake_hour - now_frac) % 24.0


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

    # Morning protection: the end of the active window is when the user is
    # back at the computer. A session started now anchors a 5h window; never
    # start one that would still be hot when they sit down — otherwise a 6am
    # resume locks them out until 11am.
    start, wake = config.active_hours
    if start != wake:
        remaining = hours_until_wake(now, wake)
        if remaining < FIVE_HOUR_WINDOW:
            return Decision(
                False,
                f"morning protection: a 5h window started now would still be "
                f"open at {wake:02d}:00 (you're back in {remaining:.1f}h)",
            )

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

    # Weekly pacing: only spend overnight budget if the week is being
    # consumed slower than time is passing, with a safety margin so the
    # following workdays aren't starved. E.g. 70% used with 5 of 7 days
    # left means the week is burning ~2.5x too fast -> hold.
    week_used = usage.seven_day.utilization
    days_left = days_until_weekly_reset(usage, now)
    elapsed_pct = (1.0 - min(days_left, 7.0) / 7.0) * 100.0
    allowed = elapsed_pct + PACING_MARGIN
    if week_used > allowed:
        return Decision(
            False,
            f"weekly burn too fast: {week_used:.0f}% used with {days_left:.1f} "
            f"days left (pace allows {allowed:.0f}%)",
        )

    return Decision(
        True,
        f"wiggle room: {week_used:.0f}% of week used, {days_left:.1f} days to "
        f"reset (pace allows {allowed:.0f}%)",
    )
