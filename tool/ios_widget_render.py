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


def verify(directory: Path):
    total = 0
    for locale in LOCALES:
        report = json.loads((directory / f"report-{locale}.json").read_text())
        cases = report["cases"]
        expected = 81 if locale == "en" else 36
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
        if names != expected_names:
            raise ValueError(f"Missing or unexpected render cases for {locale}")
        total += len(cases)
    if total != 441:
        raise ValueError("Incomplete aggregate render matrix")
    (directory / "VERIFIED.json").write_text(json.dumps({
        "scope": "shared SwiftUI layout in isolated native app; not installed WidgetKit",
        "rendered_cases": total, "locales": list(LOCALES),
        "families": ["small", "medium", "large"],
        "configurations": ["nowPlaying", "flowRadio", "coverFlow"],
        "text_sizes": ["large", "accessibility5"],
        "appearance": ["light", "dark"],
        "additional_english_states": ["paused", "buffering", "stale", "empty", "unavailable"],
    }, indent=2) + "\n")
    print(f"PASS: {total} actual native SwiftUI images, 11 locales, all families/configurations")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE:
        raise ValueError("Only the isolated native widget render app may run")
    args.output.mkdir(parents=True, exist_ok=False)
    boot_render_simulator()
    udid = os.environ["IOS_SIMULATOR_UDID"]
    command("xcrun", "simctl", "install", udid, str(args.app), timeout=90)
    container = Path(command("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"))
    for locale in LOCALES:
        with (args.output / f"launch-{locale}.log").open("w") as log:
            subprocess.run([
                "xcrun", "simctl", "launch", "--console", udid, BUNDLE,
                "--render-locale", locale, "-AppleLanguages", f'("{locale}")',
            ], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=150)
    shutil.copytree(container / "Documents/WidgetRenderProof", args.output / "images")
    verify(args.output / "images")


if __name__ == "__main__":
    main()
