import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ios_widget_live_capture as live


class LiveCapturePolicyTests(unittest.TestCase):
    token = "ed18821d-ec6f-4563-b2e6-8f6ab6312851"

    def report(self, **overrides):
        return {"token": self.token, "appearance": "light", "bundle": live.BUNDLE,
                "active_scene": True, **overrides}

    def test_readiness_requires_exact_launch_identity_and_active_scene(self):
        live.require_ready(self.report(), self.token, "light")
        for overrides in ({"token": "old-launch"}, {"bundle": "app.lokal.mobile"},
                          {"active_scene": False}, {"appearance": "dark"}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                live.require_ready(self.report(**overrides), self.token, "light")

    def test_capture_exports_two_actual_command_outputs_per_appearance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "data/Documents/WidgetRenderProof"
            data.mkdir(parents=True)
            commands = []

            def command(*args, **kwargs):
                commands.append(args)
                if "launch" in args:
                    appearance = args[args.index("--live-appearance") + 1]
                    (data / f"live-ready-{self.token}.json").write_text(
                        json.dumps(self.report(appearance=appearance)))
                if "screenshot" in args:
                    # Header fixture tests orchestration/bounds only; this is
                    # never presented as native screenshot/render evidence.
                    Path(args[-1]).write_bytes(b"\x89PNG\r\n\x1a\n" + b"\0\0\0\rIHDR" +
                                              struct.pack(">II", 1179, 2556) + b"\0" * 1100)

            with patch.object(live.uuid, "uuid4", return_value=self.token), \
                    patch.object(live.time, "sleep"), patch.object(live.subprocess, "run") as terminate:
                live.capture("owned-device", root / "data", root / "output", command=command)
            report = json.loads((root / "output/CAPTURED.json").read_text())
            self.assertEqual(len(list((root / "output").glob("*.png"))), 4)
            self.assertFalse(report["automatic_progress_animation_acceptance"])
            self.assertEqual(len(report["cases"]), 2)
            self.assertEqual(sum("launch" in args for args in commands), 2)
            self.assertEqual(terminate.call_count, 2)

    def test_capture_failure_keeps_primary_error_without_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "data/Documents/WidgetRenderProof"
            data.mkdir(parents=True)
            (data / f"live-ready-{self.token}.json").write_text(json.dumps(self.report()))
            failure = subprocess.CalledProcessError(1, ["controlled-screenshot"])
            launches = []

            def command(*args, **kwargs):
                if "launch" in args:
                    launches.append(args)
                else:
                    raise failure

            with patch.object(live.uuid, "uuid4", return_value=self.token), \
                    patch.object(live.time, "sleep"), \
                    patch.object(live.subprocess, "run", side_effect=subprocess.TimeoutExpired("cleanup", 15)):
                with self.assertRaises(subprocess.CalledProcessError) as observed:
                    live.capture("owned-device", root / "data", root / "output", command=command)
            self.assertIs(observed.exception, failure)
            self.assertEqual(len(launches), 1)
            self.assertTrue((root / "output/cleanup-light.log").is_file())

    def test_cleanup_failure_also_fails_an_otherwise_successful_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "data/Documents/WidgetRenderProof"
            data.mkdir(parents=True)
            (data / f"live-ready-{self.token}.json").write_text(json.dumps(self.report()))

            def command(*args, **kwargs):
                if "screenshot" in args:
                    Path(args[-1]).write_bytes(b"\x89PNG\r\n\x1a\n" + b"\0\0\0\rIHDR" +
                                              struct.pack(">II", 1179, 2556) + b"\0" * 1100)

            with patch.object(live.uuid, "uuid4", return_value=self.token), \
                    patch.object(live.time, "sleep"), \
                    patch.object(live.subprocess, "run", side_effect=subprocess.TimeoutExpired("cleanup", 15)):
                with self.assertRaises(subprocess.TimeoutExpired):
                    live.capture("owned-device", root / "data", root / "output", command=command)


if __name__ == "__main__":
    unittest.main()
