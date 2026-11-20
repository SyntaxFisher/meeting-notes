import tempfile
import unittest
from pathlib import Path
from unittest import mock

import devenv
import teams_update


def report(score=None, meeting_exit=0, scenario="standup", **extra):
    return {"teams": "2.0",
            "runs": [{"scenario": scenario, "meeting_exit": meeting_exit, "score": score}],
            "previous": None, "app_log": {"counts": {}}, **extra}


GOOD = {"wer": 0.05, "speakersExpected": 3, "speakersDetected": 3, "speakerAttribution": 0.99,
        "namedWords": 1.0, "nameAccuracy": 0.99, "mutedSpeechLeaked": 0.0}


class TeamsUpdateTests(unittest.TestCase):
    def test_release_comes_from_the_macos_build_settings(self):
        config = {"BuildSettings": {"WebView2Canary": {"macOS": {
            "latestVersion": "26300.1.2.3", "buildLink": "https://example.invalid/Teams.pkg"}}}}
        self.assertEqual(teams_update.parse_release(config),
                         {"version": "26300.1.2.3", "url": "https://example.invalid/Teams.pkg"})
        with self.assertRaises(RuntimeError):
            teams_update.parse_release({"BuildSettings": {}})

    def test_pending_work_installs_newer_releases_and_verifies_unchecked_builds(self):
        latest = {"version": "26300.1.2.3"}
        self.assertEqual(teams_update.pending_work({}, latest, "26289.9.9.9")["action"], "install")
        verified = {"verified": {"version": "26300.1.2.3"}}
        self.assertIsNone(teams_update.pending_work(verified, latest, "26300.1.2.3"))
        self.assertEqual(teams_update.pending_work({}, latest, "26300.1.2.3")["action"], "verify")
        self.assertEqual(teams_update.pending_work({}, None, "26300.1.2.3")["action"], "verify")

    def test_a_good_meeting_is_green(self):
        self.assertEqual(teams_update.verdict_for(report(GOOD)), ("green", []))

    def test_failed_or_unscored_meetings_are_red(self):
        self.assertEqual(teams_update.verdict_for(report(GOOD, meeting_exit=1))[0], "red")
        self.assertEqual(teams_update.verdict_for(report(None))[0], "red")
        self.assertEqual(teams_update.verdict_for(report(None, error="Teams is signed out"))[0],
                         "red")

    def test_lost_names_or_leaked_muted_speech_are_red(self):
        self.assertEqual(teams_update.verdict_for(report({**GOOD, "namedWords": 0.1}))[0], "red")
        self.assertEqual(teams_update.verdict_for(report({**GOOD, "nameAccuracy": None}))[0], "red")
        self.assertEqual(teams_update.verdict_for(report({**GOOD, "mutedSpeechLeaked": 0.5}))[0],
                         "red")

    def test_regressions_against_the_previous_build_warn(self):
        previous = {"teams": "1.0", "runs": [{"scenario": "standup", "score": GOOD}]}
        level, reasons = teams_update.verdict_for(
            report({**GOOD, "speakerAttribution": 0.8}, previous=previous))
        self.assertEqual(level, "yellow")
        self.assertIn("speakerAttribution", reasons[0])
        self.assertEqual(teams_update.verdict_for(
            report({**GOOD, "wer": 0.07}, previous=previous))[0], "green")
        self.assertEqual(teams_update.verdict_for(
            report({**GOOD, "speakerAttribution": 0.8}, scenario="other", previous=previous))[0],
            "green", "Runs compare only with the same scenario")
        self.assertEqual(teams_update.verdict_for(
            report(GOOD, app_log={"counts": {"teams.slowRead": 2}}))[0], "yellow")

    def test_every_scenario_counts(self):
        two = report(GOOD)
        two["runs"].append({"scenario": "hidden", "meeting_exit": 0,
                            "score": {**GOOD, "mutedSpeechLeaked": 0.5}})
        level, reasons = teams_update.verdict_for(two)
        self.assertEqual(level, "red")
        self.assertTrue(reasons[0].startswith("red: hidden:"))
        self.assertIn("## hidden", teams_update.summary_markdown(
            {**two, "verdict": level, "reasons": reasons, "meeting_notes": "dev"}))

    def test_the_suite_plays_existing_scenarios_in_known_languages(self):
        self.assertEqual(teams_update.split_run("hidden-meeting"), ("hidden-meeting", "en"))
        self.assertEqual(teams_update.split_run("hidden-meeting@de"), ("hidden-meeting", "de"))
        for run in teams_update.SUITE:
            scenario, language = teams_update.split_run(run)
            self.assertTrue((devenv.SCENARIOS / f"{scenario}.json").is_file(), run)
            self.assertIn(language, devenv.TEAMS_LANGUAGES, run)
        self.assertTrue(any(run.endswith("@de") for run in teams_update.SUITE))

    def test_the_check_runs_the_suite_before_it_starts_the_agent(self):
        calls = []
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.multiple(teams_update, STATE_DIR=Path(directory),
                                    STATE_FILE=Path(directory) / "state.json",
                                    LOCK_FILE=Path(directory) / "busy.lock",
                                    archive_installed_build=lambda: None,
                                    latest_release=lambda: {"version": "2.0"},
                                    app_version=lambda app: "1.0"), \
                mock.patch.object(teams_update, "prepare",
                                  side_effect=lambda work: calls.append("prepare") or "- done"), \
                mock.patch.object(teams_update, "start_agent_task",
                                  side_effect=lambda work, prepared: calls.append(prepared)
                                  or True):
            teams_update.command_check(trigger=True)
            teams_update.command_check(trigger=True)
            self.assertEqual(teams_update.load_state()["triggered"]["version"], "2.0")
        self.assertEqual(calls, ["prepare", "- done"], "A started agent is not started again")

    def test_a_busy_lock_defers_the_check(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.multiple(teams_update, STATE_DIR=Path(directory),
                                    LOCK_FILE=Path(directory) / "busy.lock"):
            with teams_update.exclusive():
                with self.assertRaises(RuntimeError):
                    with teams_update.exclusive():
                        pass


if __name__ == "__main__":
    unittest.main()
