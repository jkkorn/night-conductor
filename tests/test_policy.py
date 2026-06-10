from datetime import datetime, timezone

from autoconduct.config import default_config
from autoconduct.policy import (
    days_until_weekly_reset,
    in_active_hours,
    should_resume,
)
from autoconduct.usage import UsageSnapshot, Window

NOW = datetime(2026, 6, 11, 2, 0, tzinfo=timezone.utc)  # 02:00, inside window


def snapshot(five_hour=10.0, weekly=10.0, weekly_resets_in_days=3.0):
    resets = datetime(2026, 6, 14, 2, 0, tzinfo=timezone.utc)
    return UsageSnapshot(
        five_hour=Window(utilization=five_hour, resets_at=None),
        seven_day=Window(utilization=weekly, resets_at=resets),
        fetched_at=NOW,
    )


class TestInActiveHours:
    def test_midnight_wrap_inside(self):
        assert in_active_hours(NOW, (23, 7))

    def test_midnight_wrap_late_evening(self):
        evening = NOW.replace(hour=23)
        assert in_active_hours(evening, (23, 7))

    def test_midnight_wrap_outside(self):
        midday = NOW.replace(hour=12)
        assert not in_active_hours(midday, (23, 7))

    def test_non_wrapping_window(self):
        assert in_active_hours(NOW.replace(hour=10), (9, 17))
        assert not in_active_hours(NOW.replace(hour=18), (9, 17))

    def test_degenerate_always_active(self):
        assert in_active_hours(NOW.replace(hour=15), (0, 0))


class TestDaysUntilWeeklyReset:
    def test_three_days_out(self):
        assert days_until_weekly_reset(snapshot(), NOW) == 3.0

    def test_unknown_reset_is_zero(self):
        snap = UsageSnapshot(
            five_hour=Window(0.0, None),
            seven_day=Window(0.0, None),
            fetched_at=NOW,
        )
        assert days_until_weekly_reset(snap, NOW) == 0.0


class TestShouldResumeHardGates:
    def test_outside_active_hours_holds(self):
        decision = should_resume(snapshot(), default_config(), NOW.replace(hour=12))
        assert not decision.resume
        assert "active hours" in decision.reason

    def test_five_hour_ceiling_holds(self):
        decision = should_resume(snapshot(five_hour=90.0), default_config(), NOW)
        assert not decision.resume
        assert "5h" in decision.reason

    def test_weekly_ceiling_holds(self):
        decision = should_resume(snapshot(weekly=95.0), default_config(), NOW)
        assert not decision.resume
        assert "weekly" in decision.reason

    def test_low_usage_resumes(self):
        decision = should_resume(snapshot(), default_config(), NOW)
        assert decision.resume

    def test_decision_always_has_reason(self):
        for snap in (snapshot(), snapshot(five_hour=99.0), snapshot(weekly=99.0)):
            assert should_resume(snap, default_config(), NOW).reason
