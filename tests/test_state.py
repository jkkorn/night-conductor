from datetime import datetime

from autoconduct.state import NightState, load_state, night_key, save_state


class TestNightKey:
    def test_evening_belongs_to_today(self):
        now = datetime(2026, 6, 10, 23, 30)
        assert night_key(now, active_start_hour=23) == "2026-06-10"

    def test_early_morning_belongs_to_previous_night(self):
        now = datetime(2026, 6, 11, 2, 0)
        assert night_key(now, active_start_hour=23) == "2026-06-10"


class TestNightState:
    def test_with_resume_is_immutable(self):
        original = NightState(night_key="2026-06-10")
        updated = original.with_resume("abc")
        assert original.count_for("abc") == 0
        assert updated.count_for("abc") == 1

    def test_total_resumes(self):
        s = NightState("n").with_resume("a").with_resume("a").with_resume("b")
        assert s.total_resumes() == 3


class TestPersistence:
    def test_round_trip(self, tmp_path):
        path = tmp_path / "state.json"
        state = NightState("2026-06-10").with_resume("abc")
        save_state(state, path)
        loaded = load_state("2026-06-10", path)
        assert loaded.count_for("abc") == 1

    def test_new_night_resets_budget(self, tmp_path):
        path = tmp_path / "state.json"
        save_state(NightState("2026-06-10").with_resume("abc"), path)
        loaded = load_state("2026-06-11", path)
        assert loaded.count_for("abc") == 0

    def test_missing_file_is_fresh(self, tmp_path):
        loaded = load_state("2026-06-10", tmp_path / "nope.json")
        assert loaded.total_resumes() == 0

    def test_corrupt_file_is_fresh(self, tmp_path):
        path = tmp_path / "state.json"
        path.write_text("{not json")
        assert load_state("2026-06-10", path).total_resumes() == 0
