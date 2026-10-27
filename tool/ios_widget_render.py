#!/usr/bin/env python3
"""Render the actual shared widget layout in an isolated native simulator app.

This proves SwiftUI layout/image generation, not Home Screen installation,
App Group provisioning, WidgetKit scheduling or physical-device behavior.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess

import ios_simulator
from ios_widget_live_capture import capture


LOCALES = ("en", "fr", "de", "es", "it", "pt-BR", "nl", "pl", "sv", "tr", "zh-Hans")
BUNDLE = "app.lokal.widgetPreview"
INVENTORY = ("xcrun", "simctl", "list", "devices", "available", "--json")


def command(*args, timeout=60):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=timeout).strip()


def boot_render_simulator():
    """One cold-service recovery, strictly before the render app is installed."""
    try:
        ios_simulator.main()
    except subprocess.TimeoutExpired as error:
        # Only the first, pre-device inventory timeout qualifies. A runtime,
        # boot, installation or rendering failure must not enter this path.
        if tuple(error.cmd) != INVENTORY or os.environ.get("IOS_SIMULATOR_UDID"):
            raise
        developer = os.environ.get("DEVELOPER_DIR")
        if not developer:
            raise
        print("Cold CoreSimulator inventory timed out before app installation; "
              "preserving evidence and warming Simulator once", flush=True)
        subprocess.run(["open", "-a", str(Path(developer) / "Applications/Simulator.app")],
                       check=True, timeout=20)
        os.environ["IOS_SIMULATOR_SESSION_SUFFIX"] = "widget-render-inventory-recovery"
        ios_simulator.main()


def verify_visible_content(case):
    recognized = "".join(case.get("recognized_text", [])).lower()
    recognized = "".join(char for char in recognized if char.isalpha())
    if case["kind"] == "coverFlow" and case["family"] != "small":
        expected = ("songb", "songc", "songd")
    elif case["kind"] == "coverFlow":
        expected = ("songb", "artistb")
    else:
        expected = ("songa", "artista")
    if not all(word in recognized for word in expected):
        raise ValueError(f"Required visible content missing from OCR: {case['name']}")


def verify(directory: Path):
    total = 0
    for locale in LOCALES:
        report = json.loads((directory / f"report-{locale}.json").read_text())
        cases = report["cases"]
        expected = 90 if locale == "en" else 36
        if report["locale"] != locale or len(cases) != expected or report["scale"] != 2:
            raise ValueError(f"Incomplete render matrix for {locale}")
        expected_names = {
            f"{locale}-{kind}-{family}-{appearance}-{text}"
            for kind in ("nowPlaying", "flowRadio", "coverFlow")
            for family in ("small", "medium", "large")
            for appearance in ("light", "dark")
            for text in ("large", "accessibility5")
        }
        if locale == "en":
            expected_names.update(
                f"en-{kind}-{family}-{state}"
                for kind in ("nowPlaying", "flowRadio", "coverFlow")
                for family in ("small", "medium", "large")
                for state in ("paused", "buffering", "stale", "empty", "unavailable")
            )
        if locale == "en":
            expected_names.update(
                f"en-{kind}-{family}-content-proof"
                for kind in ("nowPlaying", "flowRadio", "coverFlow")
                for family in ("small", "medium", "large")
            )
        names = set()
        for case in cases:
            name = case["name"]
            if not re.fullmatch(r"[A-Za-z0-9-]{1,150}", name) or name in names:
                raise ValueError("Invalid or repeated render name")
            names.add(name)
            image = directory / (name + ".png")
            with image.open("rb") as source:
                header = source.read(24)
            if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
                raise ValueError(f"Invalid PNG: {name}")
            if struct.unpack(">II", header[16:24]) != (case["width"] * 2, case["height"] * 2):
                raise ValueError(f"Incorrect rendered bounds: {name}")
            if image.stat().st_size <= 500:
                raise ValueError(f"Empty rendered image: {name}")
            if case["state"] == "content-proof":
                verify_visible_content(case)
        if names != expected_names:
            raise ValueError(f"Missing or unexpected render cases for {locale}")
        total += len(cases)
    if total != 450:
        raise ValueError("Incomplete aggregate render matrix")
    (directory / "VERIFIED.json").write_text(json.dumps({
        "scope": "shared SwiftUI layout in isolated native app; not installed WidgetKit",
        "rendered_cases": total, "locales": list(LOCALES),
        "families": ["small", "medium", "large"],
        "configurations": ["nowPlaying", "flowRadio", "coverFlow"],
        "text_sizes": ["large", "accessibility5"],
        "appearance": ["light", "dark"],
        "additional_english_states": ["paused", "buffering", "stale", "empty", "unavailable"],
        "independent_pixel_ocr_cases": 9,
    }, indent=2) + "\n")
    print(f"PASS: {total} actual native SwiftUI images, 11 locales, all families/configurations")


def collect_failure(output: Path, stage: str, error: Exception):
    """Keep installer/launch evidence without replacing the original failure."""
    (output / "failure.json").write_text(json.dumps({
        "stage": stage, "error_type": type(error).__name__, "error": str(error),
    }, indent=2) + "\n")
    for name in ("stdout", "stderr"):
        value = getattr(error, name, None)
        if value:
            if isinstance(value, bytes):
                value = value.decode("utf-8", errors="replace")
            (output / f"failure-{name}.log").write_text(value)
    udid = os.environ.get("IOS_SIMULATOR_UDID")
    if not udid:
        return
    try:
        container = Path(command("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data", timeout=15))
        partial = container / "Documents/WidgetRenderProof"
        if partial.is_dir():
            shutil.copytree(partial, output / "partial-images")
    except (OSError, subprocess.SubprocessError) as export_error:
        (output / "partial-export-error.log").write_text(str(export_error) + "\n")
    probes = [
        (["xcrun", "simctl", "list", "devices", "available", "--json"], "failure-devices.log"),
        (["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "3m", "--style", "compact",
          "--predicate", 'process == "installd" OR process == "installcoordinationd" OR process == "SpringBoard"'],
         "failure-install-services.log"),
        (["xcrun", "simctl", "io", udid, "screenshot", str(output / "failure-screen.png")],
         "failure-screen.log"),
    ]
    for args, name in probes:
        with (output / name).open("w") as log:
            try:
                subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, check=False, timeout=20)
            except (OSError, subprocess.SubprocessError) as probe_error:
                log.write(str(probe_error) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE:
        raise ValueError("Only the isolated native widget render app may run")
    orientations = info.get("UISupportedInterfaceOrientations")
    allowed = {"UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
               "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"}
    if (not isinstance(orientations, list) or not orientations
            or any(value not in allowed for value in orientations)):
        raise ValueError("The native render app must declare valid interface orientations")
    args.output.mkdir(parents=True, exist_ok=False)
    stage = "boot"
    try:
        boot_render_simulator()
        udid = os.environ["IOS_SIMULATOR_UDID"]
        stage = "install"
        command("xcrun", "simctl", "install", udid, str(args.app), timeout=120)
        stage = "container"
        container = Path(command("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"))
        for locale in LOCALES:
            stage = "render-" + locale
            with (args.output / f"launch-{locale}.log").open("w") as log:
                subprocess.run([
                    "xcrun", "simctl", "launch", "--console", udid, BUNDLE,
                    "--render-locale", locale, "-AppleLanguages", f'("{locale}")',
                ], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=150)
        stage = "export"
        shutil.copytree(container / "Documents/WidgetRenderProof", args.output / "images")
        stage = "verify"
        verify(args.output / "images")
        stage = "native-screen-progress"
        capture(udid, container, args.output / "native-screen-progress", command=command)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        try:
            collect_failure(args.output, stage, error)
        except OSError as evidence_error:
            print(f"Could not preserve render failure evidence: {evidence_error}", flush=True)
        raise



if __name__ == "__main__":
    main()
