#!/usr/bin/env python3
"""Read-only iOS source inventory. This does not certify build/device readiness.

Python 3.11+, no third-party dependencies. Run flutter pub get first for the
resolved iOS plugin inventory; the remaining checks also work without Flutter.
"""

from __future__ import annotations

import argparse
import json
import platform
import plistlib
import re
import shutil
import subprocess
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHANNEL = re.compile(r"\b(MethodChannel|EventChannel)\s*\(\s*(['\"])(.*?)\2", re.S)
SCAFFOLD = (
    "ios/Runner.xcodeproj/project.pbxproj",
    "ios/Runner/Info.plist",
    "ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme",
)


def inventory(root: Path) -> dict:
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=root, check=True,
        capture_output=True, text=True,
    ).stdout.strip()
    channels = []
    for path in sorted((root / "lib").rglob("*.dart")):
        if path.name.endswith((".g.dart", ".freezed.dart")):
            continue
        source = path.read_text(encoding="utf-8")
        for match in CHANNEL.finditer(source):
            channels.append({
                "kind": match[1], "name": match[3],
                "source": path.relative_to(root).as_posix(),
                "line": source.count("\n", 0, match.start()) + 1,
            })

    manifest = tomllib.loads((root / "rust/Cargo.toml").read_text())
    plugin_file = root / ".flutter-plugins-dependencies"
    ios_plugins = None
    if plugin_file.exists():
        data = json.loads(plugin_file.read_text())
        ios_plugins = sorted(
            plugin["name"] for plugin in data.get("plugins", {}).get("ios", [])
        )

    translations = (root / 'lib/l10n/generated/app_localizations.dart').read_text()
    locales = re.search(r'supportedLocales\s*=\s*<Locale>\[(.*?)\];', translations, re.S)
    if locales is None:
        raise ValueError('Cannot inventory the generated Flutter supportedLocales')
    languages = sorted(set(re.findall(r"Locale\(['\"]([a-zA-Z-]+)['\"]", locales[1])))
    info_file = root / 'ios/Runner/Info.plist'
    info = plistlib.loads(info_file.read_bytes()) if info_file.exists() else {}
    declared = info.get('CFBundleLocalizations', [])

    build_pod = (root / "rust_builder/cargokit/build_pod.sh").read_text()
    cargokit = (root / "rust/cargokit.yaml").read_text()
    quickjs = manifest["dependencies"].get("rquickjs", {})
    ios_bindgen = isinstance(quickjs, dict) and "bindgen" in quickjs.get("features", [])
    for target, config in manifest.get("target", {}).items():
        dep = config.get("dependencies", {}).get("rquickjs", {})
        if 'target_os = "ios"' in target and isinstance(dep, dict):
            ios_bindgen = ios_bindgen or "bindgen" in dep.get("features", [])
    return {
        "source_revision": revision,
        "scope": "Static source inventory; no compilation or device validation",
        "host": {
            "os": platform.system(),
            "xcodebuild_on_path": shutil.which("xcodebuild") is not None,
            "flutter_on_path": shutil.which("flutter") is not None,
        },
        "missing_ios_scaffold": [p for p in SCAFFOLD if not (root / p).is_file()],
        "localizations": {
            "flutter_languages": languages,
            "bundle_languages": declared,
            "missing_bundle_languages": sorted(set(languages) - set(declared)),
        },
        "rust": {
            "required_version": manifest["package"]["rust-version"],
            "default_features": manifest["features"].get("default", []),
            "quickjs_bindgen_explicitly_declared_for_ios": ios_bindgen,
            "cargokit_explicitly_enables_uac2": bool(
                re.search(r"^\s*-\s*uac2\s*$", cargokit, re.M)
            ),
            "pod_build_dumps_environment": bool(
                re.search(r"^\s*env\s*$", build_pod, re.M)
            ),
        },
        "resolved_ios_plugins": ios_plugins,
        "dart_channel_callsites": channels,
        "limitations": [
            "Literal channel inventory only; variables/generated calls may be absent.",
            "Channel presence does not prove a missing or working native handler.",
            "Federated Android/iOS plugins can have different package names.",
            "Plugin registration does not establish binary availability or compatibility.",
            "A scaffold does not establish startup, playback, signing, or installability.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Print structured inventory")
    parser.add_argument(
        "--require-scaffold", action="store_true",
        help="Exit 1 if the iOS runner files are absent (only a structural gate)",
    )
    parser.add_argument(
        "--require-localizations", action="store_true",
        help="Exit 1 if the iOS bundle omits a generated Flutter language",
    )
    args = parser.parse_args()
    report = inventory(ROOT)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"iOS source inventory at {report['source_revision'][:12]}")
        print(report["scope"])
        print(f"Host: {report['host']['os']}; Xcode: {report['host']['xcodebuild_on_path']}")
        missing = report["missing_ios_scaffold"]
        print("Missing iOS runner files: " + (", ".join(missing) or "none"))
        print("Flutter languages absent from the iOS bundle: " +
              (", ".join(report["localizations"]["missing_bundle_languages"]) or "none"))
        print("Rust default features: " + ", ".join(report["rust"]["default_features"]))
        print(f"Cargokit forces USB feature: {report['rust']['cargokit_explicitly_enables_uac2']}")
        print(f"QuickJS iOS binding generation declared: {report['rust']['quickjs_bindgen_explicitly_declared_for_ios']}")
        print(f"Pod build dumps environment: {report['rust']['pod_build_dumps_environment']}")
        plugins = report["resolved_ios_plugins"]
        print("Resolved iOS plugins: " + (", ".join(plugins) if plugins is not None else "unknown; run flutter pub get"))
        print(f"Literal Dart channel callsites: {len(report['dart_channel_callsites'])}")
        print("Use --json for callsite locations and inventory limitations.")
    return int(
        (args.require_scaffold and bool(report["missing_ios_scaffold"])) or
        (args.require_localizations and bool(report["localizations"]["missing_bundle_languages"]))
    )


if __name__ == "__main__":
    raise SystemExit(main())
