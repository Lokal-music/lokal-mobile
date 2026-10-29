"""Infrastructure gate policy only; these tests do not render SwiftUI."""
import os
import json
import plistlib
import tempfile
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

import ios_widget_render


class WidgetRenderStartupTest(unittest.TestCase):
    def run_boot(self, outcomes, extra_env=None):
        env = {"DEVELOPER_DIR": "/Xcode/Developer",
               "IOS_SIMULATOR_SESSION_SUFFIX": "widget-render"}
        env.update(extra_env or {})
        with patch.dict(os.environ, env, clear=True), \
             patch.object(ios_widget_render.ios_simulator, "main", side_effect=outcomes) as boot, \
             patch.object(ios_widget_render.subprocess, "run") as launch:
            ios_widget_render.boot_render_simulator()
            return boot.call_count, launch.call_count, os.environ["IOS_SIMULATOR_SESSION_SUFFIX"]

    def test_success_has_no_recovery(self):
        self.assertEqual(self.run_boot([None]), (1, 0, "widget-render"))

    def test_cold_pre_device_inventory_can_recover_once_with_distinct_evidence(self):
        timeout = subprocess.TimeoutExpired(ios_widget_render.INVENTORY, 90)
        self.assertEqual(self.run_boot([timeout, None]),
                         (2, 1, "widget-render-inventory-recovery"))

    def test_second_inventory_timeout_propagates(self):
        timeout = subprocess.TimeoutExpired(ios_widget_render.INVENTORY, 90)
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_boot([timeout, timeout])

    def test_boot_timeout_is_not_retried(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_boot([subprocess.TimeoutExpired(["xcrun", "simctl", "bootstatus", "owned", "-b"], 300)])

    def test_post_selection_inventory_timeout_is_not_retried(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_boot([subprocess.TimeoutExpired(ios_widget_render.INVENTORY, 90)],
                          {"IOS_SIMULATOR_UDID": "already-selected"})

    def test_non_timeout_failure_propagates(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_boot([subprocess.CalledProcessError(1, "simctl")])

    def test_render_process_failure_propagates_without_another_boot_or_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Preview.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": ios_widget_render.BUNDLE,
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            }))
            with patch("sys.argv", ["render", str(app), "--output", str(root / "proof")]), \
                 patch.dict(os.environ, {"IOS_SIMULATOR_UDID": "owned"}, clear=True), \
                 patch.object(ios_widget_render, "boot_render_simulator") as boot, \
                 patch.object(ios_widget_render, "collect_failure") as evidence, \
                 patch.object(ios_widget_render, "command", side_effect=["", str(root)]) as command, \
                 patch.object(ios_widget_render.subprocess, "run",
                              side_effect=subprocess.CalledProcessError(1, "native render")) as launch:
                with self.assertRaises(subprocess.CalledProcessError):
                    ios_widget_render.main()
                boot.assert_called_once()
                launch.assert_called_once()
                evidence.assert_called_once()
                self.assertEqual(evidence.call_args.args[1], "render-en")
                self.assertEqual(command.call_count, 2)
                timing = json.loads((root / "proof/launch-en-timing.json").read_text())
                self.assertEqual(timing["status"], "CalledProcessError")
                self.assertEqual(timing["timeoutSeconds"], 150)
                self.assertGreaterEqual(timing["elapsedMs"], 0)
                self.assertGreaterEqual(timing["launchFinishedAtMs"], timing["launchStartedAtMs"])

    def test_invalid_or_missing_orientations_fail_before_boot_or_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Preview.app"
            app.mkdir()
            for orientations in (None, [], ["InvalidOrientation"], "UIInterfaceOrientationPortrait"):
                with self.subTest(orientations=orientations):
                    info = {"CFBundleIdentifier": ios_widget_render.BUNDLE}
                    if orientations is not None:
                        info["UISupportedInterfaceOrientations"] = orientations
                    (app / "Info.plist").write_bytes(plistlib.dumps(info))
                    with patch("sys.argv", ["render", str(app), "--output", str(root / "proof")]), \
                         patch.object(ios_widget_render, "boot_render_simulator") as boot, \
                         patch.object(ios_widget_render, "command") as command:
                        with self.assertRaisesRegex(ValueError, "orientations"):
                            ios_widget_render.main()
                        boot.assert_not_called()
                        command.assert_not_called()


class WidgetVisibleContentTest(unittest.TestCase):
    def case(self, kind, family, text):
        return {"name": "actual-native-pixel-proof", "kind": kind,
                "family": family, "recognized_text": text}

    def test_title_alone_cannot_pass_required_artist_visibility(self):
        for kind in ("nowPlaying", "flowRadio"):
            with self.assertRaisesRegex(ValueError, "visible content"):
                ios_widget_render.verify_visible_content(self.case(kind, "medium", ["SongA", "Open Lokal"]))

    def test_medium_cover_flow_requires_all_three_recordings(self):
        with self.assertRaisesRegex(ValueError, "visible content"):
            ios_widget_render.verify_visible_content(self.case("coverFlow", "medium", ["SongB", "ArtistB"]))
        ios_widget_render.verify_visible_content(self.case("coverFlow", "medium", ["Song B", "Song C", "Song D"]))

    def test_ocr_word_spacing_and_case_preserve_content_identity(self):
        ios_widget_render.verify_visible_content(self.case("nowPlaying", "small", ["SONG A", "Artist A"]))
        ios_widget_render.verify_visible_content(self.case("coverFlow", "small", ["Song B", "Artist B"]))


if __name__ == "__main__":
    unittest.main()
