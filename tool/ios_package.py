#!/usr/bin/env python3
"""Inspect a release device app and package an unsigned IPA for local signing."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def inspect_bundle(app: Path) -> dict:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    executable = app / info["CFBundleExecutable"]
    if not os.access(executable, os.X_OK):
        raise ValueError("The main app binary is missing or not executable")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise ValueError("IPA must contain a device app, never a simulator app")
    if "audio" not in info.get("UIBackgroundModes", []):
        raise ValueError("Background playback configuration is absent")
    def version(value: str) -> tuple[int, ...]:
        parts = tuple(int(p) for p in value.split('.'))
        return parts + (0,) * (3 - len(parts))

    minimum = version(info["MinimumOSVersion"])
    binaries = [executable]
    for framework in app.glob("Frameworks/*.framework"):
        metadata = plistlib.loads((framework / "Info.plist").read_bytes())
        binaries.append(framework / metadata["CFBundleExecutable"])
    binaries.extend(app.glob("Frameworks/*.dylib"))
    for binary in binaries:
        archs = command("xcrun", "lipo", "-archs", str(binary)).split()
        if "arm64" not in archs or "x86_64" in archs or "i386" in archs:
            raise ValueError(f"Not an arm64 device binary: {binary.name}: {archs}")
        load_commands = command("xcrun", "vtool", "-show-build", str(binary))
        platforms = re.findall(r"^\s*platform\s+(\S+)", load_commands, re.M)
        if not platforms or any(p != "IOS" for p in platforms):
            raise ValueError(f"Wrong Mach-O platform in {binary.name}: {platforms}")
        floors = re.findall(r"^\s*minos\s+(\S+)", load_commands, re.M)
        if not floors or any(version(v) > minimum for v in floors):
            raise ValueError(
                f"{binary.name} requires iOS {floors}, above the app's "
                f"declared minimum {info['MinimumOSVersion']}"
            )
    return {
        "bundle_id": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "minimum_ios": info["MinimumOSVersion"],
        "binaries_inspected": len(binaries),
        "signing": "Unsigned build; must be signed locally before installation",
        "validation": "Binary/package inspection only; device acceptance is separate",
        "runtime_tests": "Consult the associated workflow run; these execute after packaging",
        "release_status": "Engineering build; not a qualified public release",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Packaging requires macOS/Xcode to inspect the actual Apple binaries")
    app, output = args.app.resolve(strict=True), args.output.resolve()
    metadata = inspect_bundle(app)
    root = Path(__file__).resolve().parents[1]
    metadata["source_commit"] = command("git", "-C", str(root), "rev-parse", "HEAD")
    metadata["source_tree"] = command("git", "-C", str(root), "rev-parse", "HEAD^{tree}")
    metadata["xcode"] = command("xcodebuild", "-version")
    flutter = json.loads(command("flutter", "--version", "--machine"))
    metadata["flutter"] = {
        key: flutter[key]
        for key in ("frameworkVersion", "frameworkRevision", "dartSdkVersion")
    }
    # Cargokit selects this pinned toolchain; the runner's default can differ.
    metadata["rust"] = command("rustc", "+1.98.0", "--version")
    metadata["cocoapods"] = command("pod", "--version")
    metadata["iphoneos_sdk"] = command("xcrun", "--sdk", "iphoneos", "--show-sdk-version")
    metadata["ffmpeg_ios_archive_sha256"] = os.environ.get("LOKAL_FFMPEG_IOS_SHA256", "not recorded")
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise ValueError("Refusing to overwrite an existing IPA; clean the output first")
    with tempfile.TemporaryDirectory(prefix="lokal-ipa-") as directory:
        payload = Path(directory) / "Payload"
        payload.mkdir()
        shutil.copytree(app, payload / app.name, symlinks=True)
        command("ditto", "-c", "-k", "--keepParent", str(payload), str(output))
    with output.open("rb") as binary:
        metadata["sha256"] = hashlib.file_digest(binary, "sha256").hexdigest()
    output.with_suffix(".ipa.sha256").write_text(f"{metadata['sha256']}  {output.name}\n")
    output.with_suffix(".ipa.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (output.parent / 'ENGINEERING-BUILD.txt').write_text(
        'Unsigned engineering build. Sign locally before installing.\n'
        'Binary/package inspection does not establish simulator or physical-device acceptance.\n'
        'Consult the associated Actions run for runtime test results.\n'
        'This artifact is not a qualified public release.\n'
    )
    for source in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        shutil.copyfile(root / source, output.parent / source)
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
