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


class TestMorningProtection:
    def test_within_five_hours_of_wake_holds(self):
        # 05:00 with wake at 07:00 -> a window started now is hot until 10:00
        early_morning = NOW.replace(hour=5)
        decision = should_resume(snapshot(), default_config(), early_morning)
        assert not decision.resume
        assert "morning protection" in decision.reason

    def test_exactly_five_hours_before_wake_resumes(self):
        # 02:00 with wake at 07:00 -> the window fully resets by 07:00
        decision = should_resume(snapshot(), default_config(), NOW)
        assert decision.resume

    def test_just_before_wake_holds(self):
        decision = should_resume(
            snapshot(), default_config(), NOW.replace(hour=6, minute=30)
        )
        assert not decision.resume


class TestWeeklyPacing:
    def test_burning_too_fast_holds(self):
        # 70% used but 5 of 7 days still left -> way ahead of pace
        resets = NOW.replace(day=16)  # 5 days out
        snap = UsageSnapshot(
            five_hour=Window(10.0, None),
            seven_day=Window(70.0, resets),
            fetched_at=NOW,
        )
        decision = should_resume(snap, default_config(), NOW)
        assert not decision.resume
        assert "burn too fast" in decision.reason

    def test_high_usage_near_reset_resumes(self):
        # 70% used with only ~half a day left -> plenty of wiggle room
        resets = NOW.replace(hour=14)  # 12h out
        snap = UsageSnapshot(
            five_hour=Window(10.0, None),
            seven_day=Window(70.0, resets),
            fetched_at=NOW,
        )
        decision = should_resume(snap, default_config(), NOW)
        assert decision.resume
        assert "wiggle room" in decision.reason

    def test_decision_always_has_reason(self):
        for snap in (snapshot(), snapshot(five_hour=99.0), snapshot(weekly=99.0)):
            assert should_resume(snap, default_config(), NOW).reason
