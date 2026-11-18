import unittest

import teams_update


def report(score=None, **extra):
    return {"teams": "2.0", "meeting_exit": 0, "score": score, "previous": None,
            "app_log": {"counts": {}}, **extra}


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
        previous = {"teams": "1.0", "score": GOOD}
        level, reasons = teams_update.verdict_for(
            report({**GOOD, "speakerAttribution": 0.8}, previous=previous))
        self.assertEqual(level, "yellow")
        self.assertIn("speakerAttribution", reasons[0])
        self.assertEqual(teams_update.verdict_for(
            report({**GOOD, "wer": 0.07}, previous=previous))[0], "green")
        self.assertEqual(teams_update.verdict_for(
            report(GOOD, app_log={"counts": {"teams.slowRead": 2}}))[0], "yellow")


if __name__ == "__main__":
    unittest.main()
