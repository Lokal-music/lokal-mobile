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


def binary_uuids(binary: Path) -> set[str]:
    return set(re.findall(r"UUID: ([0-9A-F-]+)", command("xcrun", "dwarfdump", "--uuid", str(binary))))


def inspect_smb(app: Path, executable: Path, binaries: list[Path]) -> dict:
    framework = app / 'Frameworks/libsmb2.framework/libsmb2'
    license_path = 'Frameworks/App.framework/flutter_assets/assets/licenses/libsmb2.txt'
    if framework not in binaries or not (app / license_path).is_file():
        raise ValueError('Native SMB framework or LGPL notice is missing')
    # Dart's iOS loader uses DynamicLibrary.process(), so embedding a library
    # is insufficient: it must be reachable from the executable's load graph.
    by_install_name = {'@rpath/' + binary.relative_to(app / 'Frameworks').as_posix(): binary
                       for binary in binaries if app / 'Frameworks' in binary.parents}
    pending = [executable]
    seen = set()
    while pending:
        binary = pending.pop()
        if binary in seen:
            continue
        seen.add(binary)
        for row in command('xcrun', 'otool', '-L', str(binary)).splitlines()[1:]:
            name = row.strip().split(' (compatibility version', 1)[0]
            if name in by_install_name:
                pending.append(by_install_name[name])
    if framework not in seen:
        raise ValueError('Native SMB dylib is embedded but not loaded for Dart FFI')
    return {'framework': framework.relative_to(app).as_posix(),
            'license': license_path, 'ffi_load_reachable': True,
            'upstream_archive_sha256': 'c9b05f037865affe0ebdac71a0013e1b53e72ad007b5f3a00331eeeb56ba43f1'}


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
    if minimum != version('16.0'):
        raise ValueError('The supported iPhone application floor is iOS 16.0')
    cast_resources = (
        'GoogleCastCoreResources.bundle',
        'GoogleCast.bundle/PrivacyInfo.xcprivacy',
        'LokalCastNotices.bundle/oss_licenses.bin',
        'LokalCastNotices.bundle/oss_licenses_index.plist',
    )
    for relative in cast_resources:
        if not (app / relative).exists():
            raise ValueError(f'Missing required Google Cast resource: {relative}')
    binaries = [executable]
    for framework in app.glob("Frameworks/*.framework"):
        metadata = plistlib.loads((framework / "Info.plist").read_bytes())
        binaries.append(framework / metadata["CFBundleExecutable"])
    binaries.extend(app.glob("Frameworks/*.dylib"))
    smb = inspect_smb(app, executable, binaries)
    uuids = {}
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
        uuids[binary.relative_to(app).as_posix()] = sorted(binary_uuids(binary))
    return {
        "bundle_id": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "minimum_ios": info["MinimumOSVersion"],
        "binaries_inspected": len(binaries),
        "cast_resources_verified": list(cast_resources),
        "binary_uuids": uuids,
        "native_smb": smb,
        "signing": "Unsigned build; must be signed locally before installation",
        "validation": "Binary/package inspection only; device acceptance is separate",
        "runtime_tests": "Consult the associated workflow run; these execute after packaging",
        "release_status": "Engineering build; not a qualified public release",
    }


def preserve_symbols(app: Path, output: Path, dart_symbols: Path, metadata: dict) -> None:
    expected = {uuid for values in metadata['binary_uuids'].values() for uuid in values}
    covered = set()
    symbols = output / 'Symbols'
    symbols.mkdir()
    names = []
    for dsym in sorted(app.parent.parent.rglob('*.dSYM')):
        if symbols in dsym.parents:
            continue
        matches = binary_uuids(dsym) & expected
        if not matches or matches <= covered:
            continue
        destination = symbols / dsym.name
        shutil.copytree(dsym, destination, symlinks=True)
        names.append(dsym.name)
        covered.update(matches)
    executable = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleExecutable']
    main_uuids = set(metadata['binary_uuids'][executable])
    if not main_uuids or not main_uuids <= covered:
        raise ValueError('The release app has no matching native dSYM')
    dart_files = list(dart_symbols.glob('*.symbols'))
    if not dart_files:
        raise ValueError('No Dart AOT symbols were generated by --split-debug-info')
    for source in dart_files:
        shutil.copyfile(source, symbols / source.name)
    metadata['symbols'] = {
        'matching_native_bundles': names,
        'binaries_with_native_dsyms': len(covered),
        'dart_aot_files': [source.name for source in dart_files],
        'coverage': 'Prebuilt third-party framework symbols depend on upstream availability',
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--dart-symbols", type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Packaging requires macOS/Xcode to inspect the actual Apple binaries")
    app, output = args.app.resolve(strict=True), args.output.resolve()
    metadata = inspect_bundle(app)
    root = Path(__file__).resolve().parents[1]
    metadata["workflow_run_id"] = os.environ.get("GITHUB_RUN_ID")
    metadata["workflow_run_attempt"] = os.environ.get("GITHUB_RUN_ATTEMPT")
    metadata["source_commit"] = command("git", "-C", str(root), "rev-parse", "HEAD")
    metadata["source_tree"] = command("git", "-C", str(root), "rev-parse", "HEAD^{tree}")
    metadata["xcode"] = command("xcodebuild", "-version")
    flutter = json.loads(command("flutter", "--version", "--machine"))
    metadata["flutter"] = {
        key: flutter[key]
        for key in ("frameworkVersion", "frameworkRevision", "engineRevision", "dartSdkVersion")
    }
    # Cargokit selects this pinned toolchain; the runner's default can differ.
    metadata["rust"] = command("rustc", "+1.98.0", "--version")
    metadata["cocoapods"] = command("pod", "--version")
    metadata["iphoneos_sdk"] = command("xcrun", "--sdk", "iphoneos", "--show-sdk-version")
    metadata["ffmpeg_ios_archive_sha256"] = os.environ.get("LOKAL_FFMPEG_IOS_SHA256", "not recorded")
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise ValueError("Refusing to overwrite an existing IPA; clean the output first")
    if args.dart_symbols is not None:
        preserve_symbols(app, output.parent, args.dart_symbols, metadata)
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
