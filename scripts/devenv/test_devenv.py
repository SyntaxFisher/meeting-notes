import argparse
import array
import math
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import Mock, patch
import wave

import devenv


class LivePlaybackTests(unittest.TestCase):
    def test_scoring_rejects_split_and_truncated_recordings(self):
        first = {"id": "first", "started_at": "2026-01-01T12:00:00+00:00",
                 "ended_at": "2026-01-01T12:00:10+00:00", "status": "complete"}
        second = {**first, "id": "second", "started_at": "2026-01-01T12:00:12+00:00",
                  "ended_at": "2026-01-01T12:01:00+00:00"}
        from datetime import datetime
        expected_end = datetime.fromisoformat(second["ended_at"]).timestamp()
        with self.assertRaisesRegex(SystemExit, "split into multiple recordings"):
            devenv.check_recording_continuity([first, second], expected_end)
        with self.assertRaisesRegex(SystemExit, "before playback finished"):
            devenv.check_recording_continuity([first], expected_end)
        devenv.check_recording_continuity([{**first, "ended_at": second["ended_at"]}],
                                         expected_end)
        devenv.check_recording_continuity([{**first, "status": "recording"}], expected_end)

    def test_unmute_ignores_another_windows_stale_button(self):
        live = "Unmute mic"
        stale = "Mute mic"

        def control(action, pattern, *_):
            nonlocal live
            if action == "press":
                if re.search(pattern, live):
                    live = "Mute mic"
                    return argparse.Namespace(returncode=0)
                return argparse.Namespace(returncode=1)
            found = any(re.search(pattern, label) for label in (live, stale))
            return argparse.Namespace(returncode=0 if found else 1)

        with patch.object(devenv, "teams_control", side_effect=control):
            devenv.desktop_set_muted(False)
        self.assertEqual(live, "Mute mic")

    def test_actions_reach_the_desktop_and_guests(self):
        class Button:
            def __init__(self):
                self.pressed = "false"
                self.clicks = 0

            @property
            def first(self):
                return self

            def get_attribute(self, name):
                return self.pressed if name == "aria-pressed" else None

            def click(self, timeout=None):
                self.clicks += 1
                self.pressed = "true" if self.pressed == "false" else "false"

        class Page:
            def __init__(self):
                self.button = Button()

            def get_by_role(self, role, name):
                assert role == "button" and name.match("Raise")
                return self.button

        page = Page()
        calls = []
        with patch.object(devenv, "teams_control",
                               side_effect=lambda *args, **_: calls.append(args)), \
                patch.object(devenv, "desktop_set_muted",
                                  side_effect=lambda muted: calls.append(("muted", muted))):
            devenv.run_action({"action": "raise-hand", "speaker": "kim"}, {"kim": page})
            devenv.run_action({"action": "raise-hand", "speaker": "kim"}, {"kim": page})
            devenv.run_action({"action": "teams-view", "view": "chat"}, {})
            devenv.run_action({"action": "teams-view", "view": "meeting"}, {})
            devenv.run_action({"action": "lower-hand", "speaker": "kim"}, {"kim": page})
            devenv.run_action({"action": "mute"}, {})
        self.assertEqual(page.button.clicks, 2, "Raising a raised hand changes nothing")
        self.assertEqual(page.button.pressed, "false")
        self.assertEqual(calls[0][0], "raise")
        self.assertEqual(calls[1][0], "minimize")
        self.assertEqual(calls[2], ("raise", "--meeting"))
        self.assertEqual(calls[3], ("muted", True))
        truth = {"events": [{"at": 1, "clip": "a.wav", "speaker": "kim"},
                            {"at": 2, "action": "raise-hand", "speaker": "kim"}]}
        self.assertEqual(devenv.guest_plan(truth, "kim"), [{"id": "a.wav", "at": 1}])

    def test_muted_speech_plays_but_is_absent_from_the_expected_recording(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            clip = directory / "tone.wav"
            rate = 8000
            with wave.open(str(clip), "wb") as audio:
                audio.setparams((1, 2, rate, 0, "NONE", "not compressed"))
                audio.writeframes(array.array("h", (
                    int(9000 * math.sin(2 * math.pi * 440 * n / rate)) for n in range(rate)
                )).tobytes())
            truth = {"duration": 4, "events": [
                {"clip": str(clip), "muted": False, "at": 0},
                {"clip": str(clip), "muted": True, "at": 2},
            ]}
            for include_muted in (False, True):
                output = directory / f"{include_muted}.wav"
                devenv.mix(truth, output, include_muted=include_muted)
                with wave.open(str(output)) as audio:
                    samples = array.array("h", audio.readframes(audio.getnframes()))
                    rate = audio.getframerate()
                audible = max(map(abs, samples[rate // 10:rate // 2]))
                muted = max(map(abs, samples[rate * 2 + rate // 10:rate * 2 + rate // 2]))
                self.assertGreater(audible, 5000)
                self.assertEqual(muted > 5000, include_muted)

    def test_failed_playback_closes_guests_before_leaving_the_desktop(self):
        page = Mock()
        page.get_by_role.return_value.count.return_value = 1
        browser = Mock(contexts=[Mock(pages=[page])])
        playwright = Mock()
        playwright.chromium.launch.return_value = browser
        order = []
        browser.close.side_effect = lambda: order.append("browser")
        args = argparse.Namespace(headed=False, leave=True, no_desktop=False)
        with patch.object(devenv, "teams_control", return_value=argparse.Namespace(returncode=0)), \
                patch.object(devenv, "desktop_leave", side_effect=lambda: order.append("desktop")):
            with self.assertRaisesRegex(RuntimeError, "playback failed"):
                with devenv.guest_browser(playwright, args):
                    raise RuntimeError("playback failed")
        self.assertEqual(order, ["browser", "desktop"])
        page.get_by_role.return_value.first.click.assert_called_once()


if __name__ == "__main__":
    unittest.main()
