#!/usr/bin/env python3
"""Capture the real foreground widget layout, including native timer views.

These are compositor screenshots for visual review, not ImageRenderer output
or Home Screen/provisioning/scheduling/audio-playback acceptance.
"""
import json
from pathlib import Path
import struct
import subprocess
import time
import uuid

BUNDLE = "app.lokal.widgetPreview"


def require_ready(report, token, appearance):
    if (appearance not in ("light", "dark") or report.get("token") != token or report.get("appearance") != appearance
            or report.get("bundle") != BUNDLE or report.get("active_scene") is not True):
        raise ValueError("Live capture requires this launch's active isolated scene")


def capture(udid: str, container: Path, output: Path, *, command):
    output.mkdir(exist_ok=False)
    rows = []
    for appearance in ("light", "dark"):
        token = str(uuid.uuid4())
        ready = container / f"Documents/WidgetRenderProof/live-ready-{token}.json"
        command("xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE,
                "--live-progress-proof", token, "--live-appearance", appearance,
                "-AppleLanguages", '("en")', timeout=30)
        failed = False
        try:
            deadline = time.monotonic() + 20
            while not ready.is_file():
                if time.monotonic() >= deadline:
                    raise TimeoutError("Native live proof did not publish active-scene readiness")
                time.sleep(0.1)
            report = json.loads(ready.read_text())
            require_ready(report, token, appearance)
            # Let the active scene commit its first visible frame. The second
            # capture uses the actual OS clock; no fixture timestamp is edited.
            time.sleep(0.5)
            images = []
            for frame in range(2):
                if frame:
                    time.sleep(3)
                path = output / f"native-screen-{appearance}-{frame}.png"
                command("xcrun", "simctl", "io", udid, "screenshot", str(path), timeout=20)
                if not path.is_file() or path.stat().st_size < 1000:
                    raise ValueError("Missing native compositor screenshot")
                with path.open("rb") as source:
                    header = source.read(24)
                if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
                    raise ValueError("Invalid native compositor PNG")
                width, height = struct.unpack(">II", header[16:24])
                if width < 676 or height <= width:
                    raise ValueError("Unexpected native portrait screen bounds")
                images.append(path.name)
            rows.append({"appearance": appearance, "images": images, "native_ready": report})
        except BaseException:
            failed = True
            raise
        finally:
            # This tool owns only the isolated preview process. Cleanup must
            # not replace a capture/readiness exception with a second error.
            try:
                subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE],
                               check=True, capture_output=True, timeout=15)
            except (OSError, subprocess.SubprocessError) as error:
                (output / f"cleanup-{appearance}.log").write_text(str(error) + "\n")
                if not failed:
                    raise
    (output / "CAPTURED.json").write_text(json.dumps({
        "scope": "Actual app-hosted compositor captures for visual timer review; not installed WidgetKit",
        "automatic_progress_animation_acceptance": False,
        "cases": rows,
    }, indent=2) + "\n")
    print("Captured four foreground compositor images for native widget progress review")
