from datetime import datetime, timezone

from autoconduct.usage import parse_usage

NOW = datetime(2026, 6, 10, 12, 0, tzinfo=timezone.utc)

REAL_PAYLOAD = {
    "five_hour": {"utilization": 36.0, "resets_at": "2026-06-10T21:29:59.772100+00:00"},
    "seven_day": {"utilization": 29.0, "resets_at": "2026-06-12T05:00:00.772121+00:00"},
    "seven_day_sonnet": {"utilization": 0.0, "resets_at": None},
}


class TestParseUsage:
    def test_parses_real_payload(self):
        snap = parse_usage(REAL_PAYLOAD, NOW)
        assert snap.five_hour.utilization == 36.0
        assert snap.seven_day.utilization == 29.0
        assert snap.seven_day.resets_at.year == 2026
        assert snap.fetched_at == NOW

    def test_missing_windows_default_to_zero(self):
        snap = parse_usage({}, NOW)
        assert snap.five_hour.utilization == 0.0
        assert snap.five_hour.resets_at is None

    def test_null_utilization_defaults_to_zero(self):
        snap = parse_usage({"five_hour": {"utilization": None, "resets_at": None}}, NOW)
        assert snap.five_hour.utilization == 0.0
